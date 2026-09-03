import Foundation

/// Season / Vintage resolution for the E-L Ripeness Heatmap, transcribed from
/// the Portal cross-platform contract v1.0.0 (section 4).
///
/// The anchor is the vineyard's stored `season_start_month` / `season_start_day`
/// only. There is no hemisphere field driving Vintage anywhere in this type.
///
/// ## Why this is not `VintageResolver`
///
/// `VintageResolver` mirrors the authoritative database function
/// `resolve_vintage_year` (sql/119), which contains an explicit special case:
///
/// ```sql
/// if v_month = 1 and v_day = 1 then return v_year; end if;
/// ```
///
/// The Portal contract has **no such special case**. For a `season_start = 1/1`
/// vineyard the two rules therefore disagree by exactly one year:
///
/// | Date | `VintageResolver` (database) | Portal contract |
/// |---|---|---|
/// | 2026-02-15, start 1/1 | Vintage 2026 | Vintage 2027 |
/// | 2026-01-01, start 1/1 | Vintage 2026 | Vintage 2027 |
/// | 2025-12-31, start 1/1 | Vintage 2025 | Vintage 2026 |
///
/// Every other configuration (1 July, 1 November, and any month ≥ 2) agrees
/// exactly. This type exists so the heatmap reproduces the Portal numerically,
/// as the contract and its fixture require, **without** altering the
/// server-authoritative vintage used by Yield, Costing, Pruning and the Growth
/// Stage Summary report. Resolving that disagreement needs a product decision
/// and, most likely, a SQL change — neither of which is authorised here.
nonisolated enum ELRipenessSeason {

    static let defaultSeasonStartMonth = 7
    static let defaultSeasonStartDay = 1

    /// Contract: Feb → 29, Apr/Jun/Sep/Nov → 30, otherwise 31. Deliberately
    /// year-independent, matching the Portal's `maxDayForMonth`.
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

    /// Portal rule: `now >= start ? now.year + 1 : now.year`, where `start` is
    /// the season start in the observation's own calendar year. The boundary is
    /// inclusive of the start day.
    static func vintage(forDayKey dayKey: String, month: Int?, day: Int?) -> Int? {
        guard let date = CivilDate(dayKey: ELRipeness.dayKey(dayKey)) else { return nil }
        return vintage(for: date, month: month, day: day)
    }

    static func vintage(for date: CivilDate, month: Int?, day: Int?) -> Int {
        let settings = normaliseSeasonSettings(month: month, day: day)
        let start = CivilDate(year: date.year, month: settings.month, day: settings.day)
        return date < start ? date.year : date.year + 1
    }

    /// Inclusive season range for a Vintage label. The label is the *exclusive*
    /// end year: a season starting 1 July 2025 is Vintage 2026.
    static func seasonRange(month: Int?, day: Int?, vintage: Int) -> (startISO: String, endISO: String) {
        let settings = normaliseSeasonSettings(month: month, day: day)
        let start = CivilDate(year: vintage - 1, month: settings.month, day: settings.day)
        let endExclusive = CivilDate(year: vintage, month: settings.month, day: settings.day)
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
