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
 * Boundaries are vineyard-local: every conversion takes the vineyard's own
 * [ZoneId] (`AppUiState.seasonZone`), never the device default, so a record
 * logged at 11pm on 30 June does not change season because the phone is set to
 * another timezone. This matches iOS `AppSettings.resolvedTimeZone`.
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
    fun startEpochMs(zone: ZoneId): Long =
        start.atStartOfDay(zone).toInstant().toEpochMilli()

    /** First instant of the following season in [zone] — exclusive. */
    fun endExclusiveEpochMs(zone: ZoneId): Long =
        endExclusive.atStartOfDay(zone).toInstant().toEpochMilli()

    /** True when [date] falls inside this season. */
    fun contains(date: LocalDate): Boolean =
        !date.isBefore(start) && date.isBefore(endExclusive)

    /**
     * True when [epochMs] falls inside this season, evaluated in the vineyard's
     * [zone]. A null timestamp is excluded — undated records are reachable only
     * through the "All vintages" scope, which applies no date restriction.
     */
    fun containsEpochMs(epochMs: Long?, zone: ZoneId): Boolean {
        if (epochMs == null) return false
        return contains(Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate())
    }

    /** True when a `yyyy-MM-dd` (or ISO timestamp) string falls inside this season. */
    fun containsIsoDate(iso: String?, zone: ZoneId): Boolean {
        val date = parseIsoDate(iso, zone) ?: return false
        return contains(date)
    }

    companion object {
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

        /** The vintage in progress right now, in the vineyard's [zone]. */
        fun currentVintage(
            seasonStartMonth: Int,
            seasonStartDay: Int,
            zone: ZoneId,
        ): Int = VintageResolver.vintageYear(LocalDate.now(zone), seasonStartMonth, seasonStartDay)

        /**
         * Every vintage actually represented by [epochMs] values, descending.
         *
         * The selector is driven by real data rather than an arbitrary span: a
         * vineyard with twenty years of history gets twenty options, one with
         * two months of history gets one. Callers pass the dates of records
         * already in scope for that vineyard and surface, so soft-deleted rows
         * are excluded by construction. Undated records contribute nothing —
         * they are reachable only via "All vintages".
         */
        fun representedVintages(
            epochMs: List<Long?>,
            seasonStartMonth: Int,
            seasonStartDay: Int,
            zone: ZoneId,
        ): List<Int> = epochMs
            .asSequence()
            .filterNotNull()
            .map { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
            .map { VintageResolver.vintageYear(it, seasonStartMonth, seasonStartDay) }
            .filter { it > 0 }
            .distinct()
            .sortedDescending()
            .toList()

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
        fun parseIsoDate(iso: String?, zone: ZoneId): LocalDate? {
            val raw = iso?.trim().orEmpty()
            if (raw.isEmpty()) return null
            runCatching { return LocalDate.parse(raw.take(10)) }
            return runCatching { Instant.parse(raw).atZone(zone).toLocalDate() }.getOrNull()
        }

        /** Epoch millis for an ISO date/timestamp, evaluated in [zone]. */
        fun epochMsOf(iso: String?, zone: ZoneId): Long? {
            val raw = iso?.trim().orEmpty()
            if (raw.isEmpty()) return null
            runCatching { return Instant.parse(raw).toEpochMilli() }
            return runCatching {
                LocalDate.parse(raw.take(10)).atStartOfDay(zone).toInstant().toEpochMilli()
            }.getOrNull()
        }
    }
}

/**
 * What the operator has chosen in a season selector.
 *
 * [Automatic] is the resting state: it defers to the default rule (the current
 * season when it holds records, otherwise All) so a screen keeps rolling over on
 * its own instead of pinning itself to whichever season was current the day it
 * was first opened.
 */
sealed interface SeasonSelection {
    data object Automatic : SeasonSelection
    data object All : SeasonSelection
    data class Vintage(val year: Int) : SeasonSelection
}

/**
 * A resolved season filter: the option list, the effective window, and the
 * membership test every list, total, chart and export on a screen shares.
 *
 * Screens hold a [SeasonSelection] and rebuild a `SeasonScope` from the dates of
 * the records they are showing, so a selection can never drift out of sync with
 * a heading. Mirrors the iOS `SeasonScope`.
 */
data class SeasonScope(
    /** Effective vintage, or null for **All vintages**. */
    val vintage: Int?,
    /** Effective window, or null for All vintages (no date restriction). */
    val window: SeasonWindow?,
    /** Vintage in progress, vineyard-local. */
    val currentVintage: Int,
    /** Vintages that actually hold records on this surface, descending. */
    val available: List<Int>,
    /** The vineyard's timezone, so callers filter in the same zone. */
    val zone: ZoneId,
) {
    /** True when no date restriction is applied. */
    val isAll: Boolean get() = window == null

    /**
     * Membership test. Under All vintages EVERY record passes — including
     * records with no usable event date, which would otherwise be invisible.
     */
    fun contains(epochMs: Long?): Boolean {
        val w = window ?: return true
        return w.containsEpochMs(epochMs, zone)
    }

    /** Membership test for an ISO date/timestamp string. */
    fun containsIso(iso: String?): Boolean {
        val w = window ?: return true
        return w.containsIsoDate(iso, zone)
    }

    /** "All vintages" or "2027". */
    val title: String get() = vintage?.toString() ?: ALL_TITLE

    companion object {
        const val ALL_TITLE = "All vintages"

        /**
         * Builds a scope from the records on a surface.
         *
         * @param eventDates the operational date of each record currently in
         *   scope for this vineyard and surface (soft-deleted rows already
         *   excluded). Records with no usable date pass null.
         */
        fun resolve(
            eventDates: List<Long?>,
            selection: SeasonSelection,
            seasonStartMonth: Int,
            seasonStartDay: Int,
            zone: ZoneId,
        ): SeasonScope {
            val current = SeasonWindow.currentVintage(seasonStartMonth, seasonStartDay, zone)
            val available = SeasonWindow.representedVintages(
                eventDates, seasonStartMonth, seasonStartDay, zone,
            )

            val effective: Int? = when (selection) {
                is SeasonSelection.All -> null
                // A chosen season that no longer holds records (last record
                // deleted, or a vineyard switch) falls back to All rather than
                // stranding the operator on an empty screen.
                is SeasonSelection.Vintage -> selection.year.takeIf { it in available }
                // Default to the current season only when it has something to show.
                is SeasonSelection.Automatic -> current.takeIf { it in available }
            }

            return SeasonScope(
                vintage = effective,
                window = effective?.let {
                    SeasonWindow.forVintage(it, seasonStartMonth, seasonStartDay)
                },
                currentVintage = current,
                available = available,
                zone = zone,
            )
        }
    }
}
