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

    /** Production/costing vintage year for [date] under the given season start. */
    fun vintageYear(date: LocalDate, seasonStartMonth: Int, seasonStartDay: Int): Int {
        val month = seasonStartMonth.coerceIn(1, 12)
        val day = seasonStartDay.coerceAtLeast(1)

        // 1 January start: the season is contained in a single calendar year
        // and ends 31 December, so the vintage IS the calendar year.
        if (month == 1 && day == 1) return date.year

        // Clamp the configured day to the month's real length in this year
        // (leap-day safe: a 29 Feb start behaves as 28 Feb in non-leap years).
        val yearMonth = YearMonth.of(date.year, month)
        val start = yearMonth.atDay(minOf(day, yearMonth.lengthOfMonth()))
        return if (!date.isBefore(start)) date.year + 1 else date.year
    }

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
