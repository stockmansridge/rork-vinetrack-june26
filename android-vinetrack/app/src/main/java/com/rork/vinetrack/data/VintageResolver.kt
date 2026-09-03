package com.rork.vinetrack.data

import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId

/**
 * Shared production-vintage resolver — MIRRORS the authoritative database
 * function `resolve_vintage_year` (sql/119) and the iOS `VintageResolver`.
 *
 * Vintage rule (season-end-year): a season runs from the vineyard's shared
 * season-start Operational Preference (sql/108 — `season_start_month/day`)
 * to the day before the next season start. The vintage is the calendar year
 * in which the season ENDS:
 *  * 1 July start:     15 Jul 2026 → Vintage 2027, 15 Jan 2027 → Vintage 2027
 *  * 1 January start:  15 Feb 2026 → Vintage 2026 (season contained in one year)
 *  * 1 November start: 15 Oct 2026 → Vintage 2026, 15 Nov 2026 → Vintage 2027
 *
 * A 29 Feb season start clamps to 28 Feb in non-leap years, identical to the
 * server. The DATABASE resolver stays authoritative for stored records — this
 * mirror exists for display and offline grouping only.
 */
object VintageResolver {

    /**
     * Season-year offset — the SQL 119 rule expressed as a single number.
     *
     * A 1 January season start is contained within one calendar year, so its
     * Vintage label IS that year (offset `0`). Every other start spans a year
     * boundary and is labelled with the year the season ENDS (offset `1`).
     *
     * This is the ONE place the 1 January special case is expressed. Both the
     * year assignment and [seasonBounds] derive from it, which is what makes
     * `seasonBounds(vintageYear(d)) ∋ d` hold for every date and configuration.
     */
    fun seasonYearOffset(seasonStartMonth: Int, seasonStartDay: Int): Int =
        if (seasonStartMonth.coerceIn(1, 12) == 1 && seasonStartDay.coerceAtLeast(1) == 1) 0 else 1

    /**
     * The season start day-of-month in [year], clamped to the month's real
     * length (leap-day safe: a 29 Feb start behaves as 28 Feb in non-leap years).
     */
    fun clampedStartDay(year: Int, month: Int, day: Int): Int {
        val ym = YearMonth.of(year, month.coerceIn(1, 12))
        return day.coerceIn(1, ym.lengthOfMonth())
    }

    /**
     * Vintage year for a civil (timezone-free) calendar date. Authoritative;
     * every other overload delegates here so a timezone cannot change a Vintage.
     */
    fun vintageYear(year: Int, monthOfDate: Int, dayOfDate: Int, seasonStartMonth: Int, seasonStartDay: Int): Int {
        val startMonth = seasonStartMonth.coerceIn(1, 12)
        val startDay = seasonStartDay.coerceAtLeast(1)
        val offset = seasonYearOffset(startMonth, startDay)
        val clamped = clampedStartDay(year, startMonth, startDay)
        // Inclusive of the start day: on the start day the new season has begun.
        val onOrAfterStart = monthOfDate > startMonth || (monthOfDate == startMonth && dayOfDate >= clamped)
        return if (onOrAfterStart) year + offset else year - 1 + offset
    }

    /** Inclusive start / exclusive end of a Vintage's season. */
    fun seasonBounds(vintage: Int, seasonStartMonth: Int, seasonStartDay: Int): Pair<LocalDate, LocalDate> {
        val month = seasonStartMonth.coerceIn(1, 12)
        val day = seasonStartDay.coerceAtLeast(1)
        val startYear = vintage - seasonYearOffset(month, day)
        val start = LocalDate.of(startYear, month, clampedStartDay(startYear, month, day))
        val endExclusive = LocalDate.of(startYear + 1, month, clampedStartDay(startYear + 1, month, day))
        return start to endExclusive
    }

    /** Inclusive season date range for a Vintage label. */
    fun seasonRange(vintage: Int, seasonStartMonth: Int, seasonStartDay: Int): Pair<LocalDate, LocalDate> {
        val (start, endExclusive) = seasonBounds(vintage, seasonStartMonth, seasonStartDay)
        return start to endExclusive.minusDays(1)
    }

    /** Production/costing vintage year for [date] under the given season start. */
    fun vintageYear(date: LocalDate, seasonStartMonth: Int, seasonStartDay: Int): Int =
        vintageYear(date.year, date.monthValue, date.dayOfMonth, seasonStartMonth, seasonStartDay)

    /** Vintage year for an epoch-millisecond timestamp in [zone]. */
    fun vintageYearForEpochMs(
        epochMs: Long,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        zone: ZoneId = ZoneId.systemDefault(),
    ): Int = vintageYear(
        Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate(),
        seasonStartMonth,
        seasonStartDay,
    )

    /** Vintage year for a `yyyy-MM-dd` string; falls back to today on parse failure. */
    fun vintageYearForIsoDate(
        isoDate: String,
        seasonStartMonth: Int,
        seasonStartDay: Int,
    ): Int = vintageYear(
        runCatching { LocalDate.parse(isoDate) }.getOrDefault(LocalDate.now()),
        seasonStartMonth,
        seasonStartDay,
    )
}
