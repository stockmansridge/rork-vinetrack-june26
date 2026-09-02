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
    /// excluded. Records with no reliable event date are only reachable through
    /// the "All vintages" scope, which applies no date restriction at all.
    func contains(optional date: Date?) -> Bool {
        guard let date else { return false }
        return contains(date)
    }

    // MARK: - Construction

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

    /// Every vintage actually represented by `dates`, descending.
    ///
    /// The selector is driven by real data rather than an arbitrary span: a
    /// vineyard with twenty years of spray history gets twenty options, and one
    /// with two months of history gets one. Callers pass the dates of the
    /// records already visible on that surface, so the list is inherently
    /// scoped to that vineyard and excludes soft-deleted rows.
    ///
    /// Undated records contribute nothing — they are reachable only via the
    /// "All vintages" scope.
    static func representedVintages(
        dates: [Date?],
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone
    ) -> [Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var years = Set<Int>()
        for case let date? in dates {
            years.insert(
                VintageResolver.vintageYear(
                    for: date,
                    seasonStartMonth: seasonStartMonth,
                    seasonStartDay: seasonStartDay,
                    calendar: calendar
                )
            )
        }
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

/// What the operator has chosen in a season selector.
///
/// `automatic` is the resting state: it defers to the default rule (the current
/// season when it holds records, otherwise All) so a screen keeps rolling over
/// on its own instead of pinning itself to whichever season was current the day
/// it was first opened.
nonisolated enum SeasonSelection: Equatable, Sendable {
    case automatic
    case all
    case vintage(Int)
}

/// A resolved season filter: the option list, the effective window, and the
/// membership test every list, total, chart and export on a screen shares.
///
/// Screens hold a `SeasonSelection` and rebuild a `SeasonScope` from the dates
/// of the records they are showing. Because the scope carries the predicate,
/// the selection cannot drift out of sync with a heading.
nonisolated struct SeasonScope: Equatable, Sendable {

    /// Effective vintage, or `nil` for **All vintages**.
    let vintage: Int?

    /// Effective window, or `nil` for All vintages (no date restriction).
    let window: SeasonWindow?

    /// Vintage in progress, vineyard-local.
    let currentVintage: Int

    /// Vintages that actually hold records on this surface, descending.
    let available: [Int]

    /// True when no date restriction is applied.
    var isAll: Bool { window == nil }

    /// Membership test. Under All vintages EVERY record passes — including
    /// records with no usable event date, which would otherwise be invisible.
    func contains(_ date: Date?) -> Bool {
        guard let window else { return true }
        return window.contains(optional: date)
    }

    /// "All vintages" or "2027".
    var title: String { vintage.map { String($0) } ?? SeasonScope.allTitle }

    /// Suffix for summary captions: "· 2027" or "· All vintages".
    var captionSuffix: String { "· \(title)" }

    static let allTitle = "All vintages"

    /// Builds a scope from the records on a surface.
    ///
    /// - Parameters:
    ///   - eventDates: the operational date of each record currently in scope
    ///     for this vineyard and surface (soft-deleted rows already excluded).
    ///     Records with no usable date pass `nil`.
    ///   - selection: what the operator picked.
    static func resolve(
        eventDates: [Date?],
        selection: SeasonSelection,
        seasonStartMonth: Int,
        seasonStartDay: Int,
        timeZone: TimeZone
    ) -> SeasonScope {
        let current = SeasonWindow.currentVintage(
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: timeZone
        )
        let available = SeasonWindow.representedVintages(
            dates: eventDates,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: timeZone
        )

        let effective: Int?
        switch selection {
        case .all:
            effective = nil
        case .vintage(let chosen):
            // A chosen season that no longer holds records (last record deleted,
            // or a vineyard switch) falls back to All rather than showing an
            // empty screen with no way back.
            effective = available.contains(chosen) ? chosen : nil
        case .automatic:
            // Default to the current season only when it has something to show.
            effective = available.contains(current) ? current : nil
        }

        return SeasonScope(
            vintage: effective,
            window: effective.map {
                SeasonWindow.window(
                    vintage: $0,
                    seasonStartMonth: seasonStartMonth,
                    seasonStartDay: seasonStartDay,
                    timeZone: timeZone
                )
            },
            currentVintage: current,
            available: available
        )
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

    /// Resolves a season selector's state for a surface, from the event dates
    /// of the records it is showing.
    nonisolated func seasonScope(eventDates: [Date?], selection: SeasonSelection) -> SeasonScope {
        SeasonScope.resolve(
            eventDates: eventDates,
            selection: selection,
            seasonStartMonth: seasonStartMonth,
            seasonStartDay: seasonStartDay,
            timeZone: resolvedTimeZone
        )
    }
}
