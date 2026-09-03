import Foundation

/// Shared production-vintage resolver — MIRRORS the authoritative database
/// function `resolve_vintage_year` (sql/119) byte-for-byte in behaviour.
///
/// Vintage rule (season-end-year): a season runs from the vineyard's shared
/// season-start Operational Preference (SQL 108 — `season_start_month/day`)
/// to the day before the next season start. The vintage is the calendar year
/// in which the season ENDS:
///   * 1 July start:    15 Jul 2026 → Vintage 2027, 15 Jan 2027 → Vintage 2027
///   * 1 January start: 15 Feb 2026 → Vintage 2026 (season contained in one year)
///   * 1 November start: 15 Oct 2026 → Vintage 2026, 15 Nov 2026 → Vintage 2027
///
/// A 29 Feb season start clamps to 28 Feb in non-leap years, identical to the
/// server. The DATABASE resolver stays authoritative for stored records —
/// this mirror exists for display and offline grouping only.
nonisolated enum VintageResolver {

    // MARK: - Pure civil core (timezone-free, single source of truth)

    /// Season-year offset — the SQL 119 rule expressed as a single number.
    ///
    /// A 1 January season start is contained within one calendar year, so its
    /// Vintage label IS that year (offset `0`). Every other start spans a year
    /// boundary and is labelled with the year the season ENDS (offset `1`).
    ///
    /// This is the ONE place the 1 January special case is expressed. Both the
    /// year assignment and `seasonBounds` derive from it, which is what makes
    /// `seasonBounds(forVintage: vintageYear(of: d))` contain `d` for every
    /// date and every season configuration.
    static func seasonYearOffset(seasonStartMonth: Int, seasonStartDay: Int) -> Int {
        let month = min(max(seasonStartMonth, 1), 12)
        let day = max(seasonStartDay, 1)
        return (month == 1 && day == 1) ? 0 : 1
    }

    /// Gregorian day count for a month, leap-year aware.
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch min(max(month, 1), 12) {
        case 2:
            let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return isLeap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// The season start day-of-month in `year`, clamped to the month's real
    /// length (leap-day safe — 29 Feb behaves as 28 Feb in non-leap years).
    static func clampedStartDay(year: Int, month: Int, day: Int) -> Int {
        min(max(day, 1), daysInMonth(year: year, month: month))
    }

    /// Vintage year for a civil (timezone-free) calendar date.
    ///
    /// Authoritative; every other overload delegates here so a timezone can
    /// never change a Vintage.
    static func vintageYear(
        year: Int,
        month: Int,
        day: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> Int {
        let startMonth = min(max(seasonStartMonth, 1), 12)
        let startDay = max(seasonStartDay, 1)
        let offset = seasonYearOffset(seasonStartMonth: startMonth, seasonStartDay: startDay)
        let clamped = clampedStartDay(year: year, month: startMonth, day: startDay)
        // Inclusive of the start day: on the start day the new season has begun.
        let onOrAfterStart = month > startMonth || (month == startMonth && day >= clamped)
        return onOrAfterStart ? year + offset : year - 1 + offset
    }

    /// Inclusive-start / exclusive-end civil components of a Vintage's season.
    static func seasonBounds(
        forVintage vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int
    ) -> (start: (year: Int, month: Int, day: Int), endExclusive: (year: Int, month: Int, day: Int)) {
        let month = min(max(seasonStartMonth, 1), 12)
        let day = max(seasonStartDay, 1)
        let startYear = vintage - seasonYearOffset(seasonStartMonth: month, seasonStartDay: day)
        return (
            (startYear, month, clampedStartDay(year: startYear, month: month, day: day)),
            (startYear + 1, month, clampedStartDay(year: startYear + 1, month: month, day: day))
        )
    }

    // MARK: - Foundation entry points

    /// Production/costing vintage year for a record date under the given
    /// season-start setting.
    static func vintageYear(
        for date: Date,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        calendar: Calendar = .current
    ) -> Int {
        let day = calendar.startOfDay(for: date)
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let y = parts.year, let m = parts.month, let d = parts.day else {
            return calendar.component(.year, from: day)
        }
        return vintageYear(
            year: y,
            month: m,
            day: d,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay
        )
    }

    /// "2026 Winter Pruning · Vintage 2027"-style pairing helper: the
    /// technical season year plus the resolved vintage for `date`.
    static func vintageLabel(
        for date: Date,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        calendar: Calendar = .current
    ) -> String {
        let vintage = vintageYear(
            for: date,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            calendar: calendar
        )
        return "Vintage \(String(vintage))"
    }

    /// Inclusive season date range for a Vintage label.
    static func seasonRange(
        forVintage vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        calendar: Calendar = .current
    ) -> (start: Date, endInclusive: Date)? {
        let bounds = seasonBounds(
            forVintage: vintage,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay
        )
        guard
            let start = calendar.date(from: DateComponents(
                year: bounds.start.year, month: bounds.start.month, day: bounds.start.day
            )),
            let endExclusive = calendar.date(from: DateComponents(
                year: bounds.endExclusive.year, month: bounds.endExclusive.month, day: bounds.endExclusive.day
            )),
            let endInclusive = calendar.date(byAdding: .day, value: -1, to: endExclusive)
        else { return nil }
        return (calendar.startOfDay(for: start), calendar.startOfDay(for: endInclusive))
    }
}
