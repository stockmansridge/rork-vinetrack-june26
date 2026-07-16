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

    /// Production/costing vintage year for a record date under the given
    /// season-start setting.
    static func vintageYear(
        for date: Date,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        calendar: Calendar = .current
    ) -> Int {
        let day = calendar.startOfDay(for: date)
        let year = calendar.component(.year, from: day)
        let month = min(max(seasonStartMonth, 1), 12)
        let startDay = max(seasonStartDay, 1)

        // 1 January start: the season is contained in a single calendar year
        // and ends 31 December, so the vintage IS the calendar year.
        if month == 1 && startDay == 1 { return year }

        guard let start = seasonStart(inYear: year, month: month, day: startDay, calendar: calendar) else {
            return year
        }
        return day >= start ? year + 1 : year
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

    /// Season start date in `year`, with the configured day clamped to the
    /// month's real length (leap-day safe — 29 Feb behaves as 28 Feb in
    /// non-leap years).
    private static func seasonStart(inYear year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
            return nil
        }
        let maxDay = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        let clamped = min(day, maxDay)
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: clamped)) else {
            return nil
        }
        return calendar.startOfDay(for: start)
    }
}
