import Foundation

/// A single production season expressed as a **date range**, derived from the
/// vineyard's shared season-start setting (SQL 108 `season_start_month/day`).
///
/// This is the reporting counterpart to `VintageResolver`. Where the resolver
/// answers "which vintage does this date belong to?", `SeasonWindow` answers
/// the inverse — "which dates belong to this vintage?" — so ordinary dated
/// operational records (sprays, trips, fuel, maintenance, fertiliser, growth
/// stages) can be filtered by their EXISTING event-date column with no stored
/// vintage of their own.
///
/// Stored vintage remains reserved for records inherently owned by a vintage:
/// Yield Estimates, Grape Allocations, Picking/Yield records and Damage.
///
/// Boundaries are vineyard-local: the window is built in the vineyard's
/// configured timezone (`AppSettings.resolvedTimeZone`), not the device's, so
/// an operator travelling interstate sees the same season as their colleague
/// standing in the block.
///
/// The range is half-open — `start ..< endExclusive` — which is the only form
/// that is correct for `timestamptz` event columns. An inclusive end-of-day
/// comparison silently drops records stamped in the final second of the season.
nonisolated struct SeasonWindow: Equatable, Identifiable, Sendable {

    /// Vintage year — the calendar year in which the season ENDS.
    let vintage: Int

    /// First instant of the season, vineyard-local.
    let start: Date

    /// First instant of the FOLLOWING season. Exclusive upper bound.
    let endExclusive: Date

    var id: Int { vintage }

    /// Last representable instant inside the season, for display only.
    /// Never use this for filtering — filter with `contains(_:)`.
    var displayEnd: Date { endExclusive.addingTimeInterval(-1) }

    /// True when `date` falls inside this season.
    func contains(_ date: Date) -> Bool {
        date >= start && date < endExclusive
    }

    /// True when `date` is inside the season, treating a missing date as
    /// excluded. Records with no reliable event date are reported separately
    /// rather than being silently dropped into the current season.
    func contains(optional date: Date?) -> Bool {
        guard let date else { return false }
        return contains(date)
    }

    // MARK: - Construction

    /// Number of previous seasons offered by the selector alongside the current one.
    static let previousSeasonCount = 15

    /// The window for a specific `vintage`.
    static func window(
        vintage: Int,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone
    ) -> SeasonWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let month = min(max(seasonStartMonth, 1), 12)
        let day = max(seasonStartDay, 1)

        // A 1 January season is contained within a single calendar year, so the
        // vintage IS that year. Every other season start straddles the new year,
        // so the season opens in the PREVIOUS calendar year. This mirrors
        // `VintageResolver.vintageYear` exactly — the two must never disagree,
        // or a record would be filtered out of the very season it displays as.
        let startYear = (month == 1 && day == 1) ? vintage : vintage - 1

        let start = seasonStart(inYear: startYear, month: month, day: day, calendar: calendar)
        let end = seasonStart(inYear: startYear + 1, month: month, day: day, calendar: calendar)
        return SeasonWindow(vintage: vintage, start: start, endExclusive: end)
    }

    /// The window containing `date` — i.e. the season that date belongs to.
    static func window(
        containing date: Date,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone
    ) -> SeasonWindow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let vintage = VintageResolver.vintageYear(
            for: date,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            calendar: calendar
        )
        return window(
            vintage: vintage,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: timeZone
        )
    }

    /// The vintage in progress right now, vineyard-local.
    static func currentVintage(
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone,
        now: Date = Date()
    ) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return VintageResolver.vintageYear(
            for: now,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            calendar: calendar
        )
    }

    /// Descending vintage options for a season selector: the current season
    /// plus the previous 15.
    ///
    /// `selected` is always included even when it falls outside that window, so
    /// a deep link into an old record can never land on a missing option. An
    /// `earliestRecordVintage` extends the list backwards only as far as data
    /// actually exists, so a new vineyard isn't offered 15 empty seasons.
    static func availableVintages(
        currentVintage: Int,
        selected: Int? = nil,
        earliestRecordVintage: Int? = nil
    ) -> [Int] {
        var years = Set<Int>([currentVintage])
        let floor = max(
            currentVintage - previousSeasonCount,
            earliestRecordVintage ?? (currentVintage - previousSeasonCount)
        )
        if floor <= currentVintage {
            for year in floor...currentVintage { years.insert(year) }
        }
        if let selected { years.insert(selected) }
        return years.filter { $0 > 0 }.sorted(by: >)
    }

    /// "2027 · Current" for the season in progress, otherwise "2027".
    static func label(for vintage: Int, currentVintage: Int) -> String {
        vintage == currentVintage ? "\(String(vintage)) · Current" : String(vintage)
    }

    /// Season start in `year`, with the configured day clamped to the month's
    /// real length so a 29 February start behaves as 28 February in non-leap
    /// years — identical to the server resolver.
    private static func seasonStart(inYear year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        guard let firstOfMonth = calendar.date(from: components) else {
            return Date(timeIntervalSince1970: 0)
        }
        let maxDay = calendar.range(of: .day, in: .month, for: firstOfMonth)?.count ?? 28
        components.day = min(day, maxDay)
        guard let start = calendar.date(from: components) else { return firstOfMonth }
        return calendar.startOfDay(for: start)
    }
}

extension AppSettings {
    /// Vintage in progress for this vineyard, using its shared season start and
    /// its own timezone.
    nonisolated var currentSeasonVintage: Int {
        SeasonWindow.currentVintage(
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: resolvedTimeZone
        )
    }

    /// Season window for `vintage` under this vineyard's settings.
    nonisolated func seasonWindow(for vintage: Int) -> SeasonWindow {
        SeasonWindow.window(
            vintage: vintage,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: resolvedTimeZone
        )
    }

    /// Season window containing `date` under this vineyard's settings.
    nonisolated func seasonWindow(containing date: Date) -> SeasonWindow {
        SeasonWindow.window(
            containing: date,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: resolvedTimeZone
        )
    }
}
