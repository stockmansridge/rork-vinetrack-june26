package com.rork.vinetrack.data.resistance

import java.util.Calendar
import java.util.TimeZone

/**
 * A growing season, identified explicitly rather than by calendar year.
 *
 * Australian viticulture runs across the new year — the 2026/27 season starts in
 * winter 2026 and finishes after the 2027 harvest. Counting "applications this
 * season" by calendar year would split every season in half at 31 December,
 * resetting seasonal maximums mid-canopy, which is the single easiest way to
 * silently licence a rotation the strategy forbids.
 *
 * VineTrack already stores a shared per-vineyard season start (month/day, sql/108,
 * surfaced as `AppUiState.seasonStartMonth`/`seasonStartDay`). This type is the
 * domain abstraction over that setting; it adds no database column.
 *
 * Mirrors iOS `ResistanceSeason.swift`.
 */
data class ResistanceSeason(
    /** Display and comparison identity, e.g. `"2026/27"`. */
    val id: String,
    /** Calendar year the season began. */
    val startYear: Int,
    val startEpochMs: Long,
    /** Exclusive: the instant the following season begins. */
    val endEpochMs: Long,
) {
    fun contains(epochMs: Long): Boolean = epochMs >= startEpochMs && epochMs < endEpochMs
}

/**
 * Resolves instants onto seasons for a vineyard's configured season start.
 *
 * @param startMonth 1-12. Defaults to July — the conventional Australian
 *   viticultural season boundary, sitting in dormancy between last season's
 *   harvest and this season's budburst.
 * @param startDay 1-31.
 * @param timeZoneId Season boundaries are local-calendar facts, not UTC ones. A
 *   spray at 9am on 1 July is in the new season for the grower standing in the
 *   vineyard, whatever UTC thinks.
 */
class ResistanceSeasonCalendar(
    val startMonth: Int = DEFAULT_START_MONTH,
    val startDay: Int = DEFAULT_START_DAY,
    val timeZoneId: String = "Australia/Adelaide",
) {
    private val zone: TimeZone get() = TimeZone.getTimeZone(timeZoneId)

    private fun startEpochMs(year: Int): Long {
        val calendar = Calendar.getInstance(zone)
        calendar.clear()
        calendar.set(year, (startMonth - 1).coerceIn(0, 11), startDay.coerceAtLeast(1), 0, 0, 0)
        return calendar.timeInMillis
    }

    /** The season containing [epochMs]. */
    fun season(epochMs: Long): ResistanceSeason {
        val calendar = Calendar.getInstance(zone)
        calendar.timeInMillis = epochMs
        val calendarYear = calendar.get(Calendar.YEAR)
        val thisYearStart = startEpochMs(calendarYear)
        val startYear = if (epochMs >= thisYearStart) calendarYear else calendarYear - 1
        return seasonStarting(startYear)
    }

    fun seasonStarting(startYear: Int): ResistanceSeason = ResistanceSeason(
        id = seasonId(startYear),
        startYear = startYear,
        startEpochMs = startEpochMs(startYear),
        endEpochMs = startEpochMs(startYear + 1),
    )

    fun previous(season: ResistanceSeason): ResistanceSeason = seasonStarting(season.startYear - 1)

    fun next(season: ResistanceSeason): ResistanceSeason = seasonStarting(season.startYear + 1)

    companion object {
        const val DEFAULT_START_MONTH: Int = 7
        const val DEFAULT_START_DAY: Int = 1

        /** `2026` -> `"2026/27"`. */
        fun seasonId(startYear: Int): String {
            val tail = ((startYear + 1) % 100).toString().padStart(2, '0')
            return "$startYear/$tail"
        }
    }
}
