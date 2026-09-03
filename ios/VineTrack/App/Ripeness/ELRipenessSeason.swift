import Foundation

/// Season / Vintage resolution for the E-L Ripeness Heatmap.
///
/// Contract v1.1.0 section 4 makes the authoritative database resolver
/// (`resolve_vintage_year`, SQL 119) the single Vintage authority for the Portal,
/// iOS and Android alike:
///
/// > **The database / shared VintageResolver is authoritative.** No platform may
/// > invent its own season logic.
///
/// This type therefore owns **no** Vintage arithmetic. It resolves the season
/// settings fallbacks the contract specifies and then delegates every year
/// decision and every range to `VintageResolver`, which is the same helper Yield,
/// Costing, Pruning and the Growth Stage Summary already use. There is exactly one
/// Vintage implementation on this platform.
///
/// The 1 January case is the one that used to diverge: under SQL 119 a 1 January
/// season start makes the Vintage the observation's own calendar year, so
/// `2026-02-15` is Vintage 2026 (not 2027). Contract 1.1.0 adopts that rule.
nonisolated enum ELRipenessSeason {

    static let defaultSeasonStartMonth = 7
    static let defaultSeasonStartDay = 1

    /// Contract: Feb → 29, Apr/Jun/Sep/Nov → 30, otherwise 31. Deliberately
    /// year-independent, matching the Portal's `maxDayForMonth`. Used only to
    /// normalise the stored *setting*; the per-year leap clamp lives in
    /// `VintageResolver`.
    static func maxDayForMonth(_ month: Int) -> Int {
        if month == 2 { return 29 }
        if [4, 6, 9, 11].contains(month) { return 30 }
        return 31
    }

    /// Applies the contract's fallbacks: an out-of-range month falls back to 7,
    /// an invalid day falls back to 1, and the day is clamped to the month's
    /// maximum.
    static func normaliseSeasonSettings(month: Int?, day: Int?) -> (month: Int, day: Int) {
        var m = month ?? defaultSeasonStartMonth
        if m < 1 || m > 12 { m = defaultSeasonStartMonth }
        var d = day ?? defaultSeasonStartDay
        if d < 1 { d = defaultSeasonStartDay }
        d = min(d, maxDayForMonth(m))
        return (m, d)
    }

    /// Vintage for an ISO day key, or `nil` when the key cannot be parsed.
    static func vintage(forDayKey dayKey: String, month: Int?, day: Int?) -> Int? {
        guard let date = CivilDate(dayKey: ELRipeness.dayKey(dayKey)) else { return nil }
        return vintage(for: date, month: month, day: day)
    }

    /// Delegates to the shared, database-mirroring resolver.
    static func vintage(for date: CivilDate, month: Int?, day: Int?) -> Int {
        let settings = normaliseSeasonSettings(month: month, day: day)
        return VintageResolver.vintageYear(
            year: date.year,
            month: date.month,
            day: date.day,
            seasonStartMonth: settings.month,
            seasonStartDay: settings.day
        )
    }

    /// Inclusive season range for a Vintage label, derived from the same shared
    /// resolver as `vintage(for:month:day:)`. Because both come from
    /// `VintageResolver.seasonYearOffset`, the range for a date's own Vintage is
    /// guaranteed to contain that date.
    static func seasonRange(month: Int?, day: Int?, vintage: Int) -> (startISO: String, endISO: String) {
        let settings = normaliseSeasonSettings(month: month, day: day)
        let bounds = VintageResolver.seasonBounds(
            forVintage: vintage,
            seasonStartMonth: settings.month,
            seasonStartDay: settings.day
        )
        let start = CivilDate(year: bounds.start.year, month: bounds.start.month, day: bounds.start.day)
        let endExclusive = CivilDate(
            year: bounds.endExclusive.year,
            month: bounds.endExclusive.month,
            day: bounds.endExclusive.day
        )
        return (start.iso, endExclusive.adding(days: -1).iso)
    }

    /// Vintages that actually contain observations, newest first.
    static func availableVintages(
        _ observations: [ELRipeness.Observation],
        month: Int?,
        day: Int?
    ) -> [Int] {
        var seen = Set<Int>()
        for o in observations {
            if let v = vintage(forDayKey: o.dateISO, month: month, day: day) { seen.insert(v) }
        }
        return seen.sorted(by: >)
    }

    /// Defaults to the current Vintage when it has observations, otherwise the
    /// newest Vintage that does.
    static func defaultVintage(
        _ observations: [ELRipeness.Observation],
        month: Int?,
        day: Int?,
        today: CivilDate
    ) -> Int? {
        let available = availableVintages(observations, month: month, day: day)
        guard !available.isEmpty else { return nil }
        let current = vintage(for: today, month: month, day: day)
        return available.contains(current) ? current : available.first
    }

    /// Filters observations to a Vintage by inclusive day-key comparison.
    static func filter(
        _ observations: [ELRipeness.Observation],
        toVintage vintage: Int,
        month: Int?,
        day: Int?
    ) -> [ELRipeness.Observation] {
        let range = seasonRange(month: month, day: day, vintage: vintage)
        return ELRipeness.filterToVintage(observations, startISO: range.startISO, endISO: range.endISO)
    }
}
