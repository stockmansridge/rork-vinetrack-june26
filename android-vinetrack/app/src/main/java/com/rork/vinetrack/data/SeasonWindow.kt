package com.rork.vinetrack.data

import java.time.Instant
import java.time.LocalDate
import java.time.YearMonth
import java.time.ZoneId

/**
 * A single production season expressed as a **date range**, derived from the
 * vineyard's shared season-start setting (sql/108 `season_start_month/day`).
 *
 * Reporting counterpart to [VintageResolver]: where the resolver answers "which
 * vintage does this date belong to?", `SeasonWindow` answers the inverse —
 * "which dates belong to this vintage?" — so ordinary dated operational records
 * (sprays, trips, fuel, maintenance, fertiliser, growth stages) can be filtered
 * by their EXISTING event-date column with no stored vintage of their own.
 *
 * Stored vintage stays reserved for records inherently owned by a vintage:
 * Yield Estimates, Grape Allocations, Picking/Yield records and Damage.
 *
 * The range is half-open — `start until endExclusive` — the only form that is
 * correct for timestamp columns. An inclusive end-of-day bound silently drops
 * records stamped in the final second of the season.
 *
 * Mirrors the iOS `SeasonWindow`; the two must not diverge.
 */
data class SeasonWindow(
    /** Vintage year — the calendar year in which the season ENDS. */
    val vintage: Int,
    /** First day of the season, vineyard-local. */
    val start: LocalDate,
    /** First day of the FOLLOWING season. Exclusive upper bound. */
    val endExclusive: LocalDate,
) {
    /** Last day inside the season — for display only, never for filtering. */
    val displayEnd: LocalDate get() = endExclusive.minusDays(1)

    /** First instant of the season in [zone]. */
    fun startEpochMs(zone: ZoneId = ZoneId.systemDefault()): Long =
        start.atStartOfDay(zone).toInstant().toEpochMilli()

    /** First instant of the following season in [zone] — exclusive. */
    fun endExclusiveEpochMs(zone: ZoneId = ZoneId.systemDefault()): Long =
        endExclusive.atStartOfDay(zone).toInstant().toEpochMilli()

    /** True when [date] falls inside this season. */
    fun contains(date: LocalDate): Boolean =
        !date.isBefore(start) && date.isBefore(endExclusive)

    /**
     * True when [epochMs] falls inside this season, evaluated in [zone].
     * A null timestamp is excluded rather than being silently swept into the
     * current season — records with no reliable event date are surfaced
     * separately.
     */
    fun containsEpochMs(epochMs: Long?, zone: ZoneId = ZoneId.systemDefault()): Boolean {
        if (epochMs == null) return false
        val date = Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate()
        return contains(date)
    }

    /** True when a `yyyy-MM-dd` (or ISO timestamp) string falls inside this season. */
    fun containsIsoDate(iso: String?): Boolean {
        val date = parseIsoDate(iso) ?: return false
        return contains(date)
    }

    companion object {
        /** Previous seasons offered by a selector alongside the current one. */
        const val PREVIOUS_SEASON_COUNT = 15

        /** The window for a specific [vintage]. */
        fun forVintage(vintage: Int, seasonStartMonth: Int, seasonStartDay: Int): SeasonWindow {
            val month = seasonStartMonth.coerceIn(1, 12)
            val day = seasonStartDay.coerceAtLeast(1)

            // A 1 January season sits inside a single calendar year, so the
            // vintage IS that year. Every other start straddles the new year, so
            // the season opens in the PREVIOUS calendar year. This mirrors
            // VintageResolver.vintageYear exactly — if the two disagreed, a
            // record could be filtered out of the season it displays as.
            val startYear = if (month == 1 && day == 1) vintage else vintage - 1
            return SeasonWindow(
                vintage = vintage,
                start = seasonStart(startYear, month, day),
                endExclusive = seasonStart(startYear + 1, month, day),
            )
        }

        /** The season containing [date]. */
        fun containing(date: LocalDate, seasonStartMonth: Int, seasonStartDay: Int): SeasonWindow =
            forVintage(
                VintageResolver.vintageYear(date, seasonStartMonth, seasonStartDay),
                seasonStartMonth,
                seasonStartDay,
            )

        /** The vintage in progress right now. */
        fun currentVintage(
            seasonStartMonth: Int,
            seasonStartDay: Int,
            today: LocalDate = LocalDate.now(),
        ): Int = VintageResolver.vintageYear(today, seasonStartMonth, seasonStartDay)

        /**
         * Descending vintage options: the current season plus the previous 15.
         *
         * [selected] is always included even when outside that window, so a deep
         * link into an old record can never land on a missing option.
         * [earliestRecordVintage] trims the list to seasons that actually hold
         * data, so a young vineyard isn't offered 15 empty seasons.
         */
        fun availableVintages(
            currentVintage: Int,
            selected: Int? = null,
            earliestRecordVintage: Int? = null,
        ): List<Int> {
            val floor = maxOf(
                currentVintage - PREVIOUS_SEASON_COUNT,
                earliestRecordVintage ?: (currentVintage - PREVIOUS_SEASON_COUNT),
            )
            val years = sortedSetOf<Int>()
            if (floor <= currentVintage) for (year in floor..currentVintage) years.add(year)
            years.add(currentVintage)
            selected?.let { years.add(it) }
            return years.filter { it > 0 }.sortedDescending()
        }

        /** "2027 · Current" for the season in progress, otherwise "2027". */
        fun label(vintage: Int, currentVintage: Int): String =
            if (vintage == currentVintage) "$vintage · Current" else "$vintage"

        /**
         * Season start in [year], with the configured day clamped to the month's
         * real length so a 29 February start behaves as 28 February in non-leap
         * years — identical to the server resolver.
         */
        private fun seasonStart(year: Int, month: Int, day: Int): LocalDate {
            val yearMonth = YearMonth.of(year, month)
            return yearMonth.atDay(minOf(day, yearMonth.lengthOfMonth()))
        }

        /** Parses `yyyy-MM-dd` or a full ISO timestamp; null when unusable. */
        fun parseIsoDate(iso: String?): LocalDate? {
            val raw = iso?.trim().orEmpty()
            if (raw.isEmpty()) return null
            runCatching { return LocalDate.parse(raw.take(10)) }
            return runCatching { Instant.parse(raw).atZone(ZoneId.systemDefault()).toLocalDate() }.getOrNull()
        }
    }
}
