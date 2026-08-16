import Foundation

/// A growing season, identified explicitly rather than by calendar year.
///
/// Australian viticulture runs across the new year — the 2026/27 season starts in
/// winter 2026 and finishes after the 2027 harvest. Counting "applications this
/// season" by calendar year would split every season in half at 31 December,
/// resetting seasonal maximums mid-canopy, which is the easiest way to silently
/// licence a rotation the strategy forbids.
///
/// VineTrack already stores a shared per-vineyard season start (month/day, sql/108).
/// This type is the domain abstraction over that setting; it adds no database
/// column.
///
/// Mirrors `ResistanceSeason.kt` on Android.
nonisolated struct ResistanceSeason: Codable, Sendable, Hashable {
    /// Display and comparison identity, e.g. `"2026/27"`.
    nonisolated var id: String
    /// Calendar year the season began.
    nonisolated var startYear: Int
    nonisolated var startEpochMs: Int64
    /// Exclusive: the instant the following season begins.
    nonisolated var endEpochMs: Int64

    nonisolated func contains(_ epochMs: Int64) -> Bool {
        epochMs >= startEpochMs && epochMs < endEpochMs
    }
}

/// Resolves instants onto seasons for a vineyard's configured season start.
///
/// Season boundaries are local-calendar facts, not UTC ones: a spray at 9am on
/// 1 July is in the new season for the grower standing in the vineyard, whatever
/// UTC thinks.
nonisolated struct ResistanceSeasonCalendar: Sendable {
    /// 1-12. Defaults to July — the conventional Australian viticultural boundary,
    /// sitting in dormancy between last season's harvest and this season's budburst.
    nonisolated var startMonth: Int
    /// 1-31.
    nonisolated var startDay: Int
    nonisolated var timeZoneIdentifier: String

    nonisolated static let defaultStartMonth = 7
    nonisolated static let defaultStartDay = 1

    nonisolated init(
        startMonth: Int = ResistanceSeasonCalendar.defaultStartMonth,
        startDay: Int = ResistanceSeasonCalendar.defaultStartDay,
        timeZoneIdentifier: String = "Australia/Adelaide"
    ) {
        self.startMonth = startMonth
        self.startDay = startDay
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(identifier: "UTC")!
        return calendar
    }

    private func startEpochMs(year: Int) -> Int64 {
        var components = DateComponents()
        components.year = year
        components.month = min(max(startMonth, 1), 12)
        components.day = max(startDay, 1)
        components.hour = 0
        components.minute = 0
        components.second = 0
        guard let date = calendar.date(from: components) else { return 0 }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The season containing `epochMs`.
    nonisolated func season(epochMs: Int64) -> ResistanceSeason {
        let date = Date(timeIntervalSince1970: Double(epochMs) / 1000)
        let calendarYear = calendar.component(.year, from: date)
        let thisYearStart = startEpochMs(year: calendarYear)
        let startYear = epochMs >= thisYearStart ? calendarYear : calendarYear - 1
        return seasonStarting(startYear)
    }

    nonisolated func seasonStarting(_ startYear: Int) -> ResistanceSeason {
        ResistanceSeason(
            id: Self.seasonId(startYear: startYear),
            startYear: startYear,
            startEpochMs: startEpochMs(year: startYear),
            endEpochMs: startEpochMs(year: startYear + 1)
        )
    }

    nonisolated func previous(_ season: ResistanceSeason) -> ResistanceSeason {
        seasonStarting(season.startYear - 1)
    }

    nonisolated func next(_ season: ResistanceSeason) -> ResistanceSeason {
        seasonStarting(season.startYear + 1)
    }

    /// `2026` -> `"2026/27"`.
    nonisolated static func seasonId(startYear: Int) -> String {
        let tail = String(format: "%02d", (startYear + 1) % 100)
        return "\(startYear)/\(tail)"
    }
}
