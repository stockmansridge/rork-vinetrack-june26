import Foundation

/// Vineyard-local four-hour forecast, always in metric units. Nil is unknown, not zero.
nonisolated struct SprayForecastPeriod: Sendable, Hashable {
    let date: String
    let startHour: Int
    let startTimeLocal: String
    let endTimeLocal: String
    let tempMinC: Double?
    let tempMaxC: Double?
    let windMaxKmh: Double?
    let humidityMinPct: Double?
    let humidityMaxPct: Double?
    let rainMm: Double?
    let sampleCount: Int

    func fillingNulls(from other: Self) -> Self {
        guard date == other.date, startHour == other.startHour else { return self }
        return Self(date: date, startHour: startHour, startTimeLocal: startTimeLocal,
                    endTimeLocal: endTimeLocal, tempMinC: tempMinC ?? other.tempMinC,
                    tempMaxC: tempMaxC ?? other.tempMaxC, windMaxKmh: windMaxKmh ?? other.windMaxKmh,
                    humidityMinPct: humidityMinPct ?? other.humidityMinPct,
                    humidityMaxPct: humidityMaxPct ?? other.humidityMaxPct,
                    rainMm: rainMm ?? other.rainMm, sampleCount: sampleCount)
    }
}

nonisolated struct SprayForecastWindow: Sendable, Equatable {
    enum Kind: Sendable { case optimal, highHumidity }
    let start: Date
    let end: Date
    let kind: Kind

    func label(in timezone: TimeZone, now: Date) -> String {
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_AU")
        clock.timeZone = timezone
        clock.dateFormat = "h:mm a"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_AU")
        day.timeZone = timezone
        day.dateFormat = "EEE"
        let today = calendar.isDate(start, inSameDayAs: now)
        let tomorrow = calendar.isDate(start, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
        let heading = today ? "Today" : tomorrow ? "Tomorrow" : day.string(from: start)
        let range = calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1))
            ? "\(clock.string(from: start)) – \(clock.string(from: end))"
            : "\(day.string(from: start)) \(clock.string(from: start)) – \(day.string(from: end)) \(clock.string(from: end))"
        return "\(heading)\n\(range) \(kind == .optimal ? "Optimal" : "High humidity")"
    }
}

/// Provider-independent Portal-default qualification and non-overlapping display bands.
nonisolated enum SprayForecastWindows {
    static func qualifiesOptimal(_ p: SprayForecastPeriod) -> Bool {
        guard let low = p.tempMinC, let high = p.tempMaxC,
              let wind = p.windMaxKmh, let rain = p.rainMm else { return false }
        return low > 10 && high < 35 && wind < 15 && rain <= 0.1
    }

    static func qualifiesHighHumidity(_ p: SprayForecastPeriod) -> Bool {
        qualifiesOptimal(p) && (p.humidityMinPct.map { $0 >= 90 } ?? false)
    }

    static func supplement(_ primary: [SprayForecastPeriod], with secondary: [SprayForecastPeriod]) -> [SprayForecastPeriod] {
        let values = Dictionary(secondary.map { ("\($0.date):\($0.startHour)", $0) }, uniquingKeysWith: { first, _ in first })
        let existing = Set(primary.map { "\($0.date):\($0.startHour)" })
        return primary.map { p in
            guard let other = values["\(p.date):\(p.startHour)"] else { return p }
            return p.fillingNulls(from: other)
        } + secondary.filter { !existing.contains("\($0.date):\($0.startHour)") }
    }

    static func windows(_ periods: [SprayForecastPeriod], timezone: TimeZone, now: Date = Date()) -> [SprayForecastWindow] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let firstDay = calendar.startOfDay(for: now)
        guard let lastDay = calendar.date(byAdding: .day, value: 5, to: firstDay) else { return [] }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timezone
        parser.dateFormat = "yyyy-MM-dd"
        let slots: [(Date, Date, SprayForecastWindow.Kind)] = periods.compactMap { p in
            guard (0..<24).contains(p.startHour), p.startHour % 4 == 0,
                  let date = parser.date(from: p.date), date >= firstDay, date < lastDay,
                  let start = calendar.date(bySettingHour: p.startHour, minute: 0, second: 0, of: date),
                  let end = p.startHour == 20
                    ? calendar.date(byAdding: .day, value: 1, to: date)
                    : calendar.date(bySettingHour: p.startHour + 4, minute: 0, second: 0, of: date),
                  end > now,
                  qualifiesOptimal(p) else { return nil }
            return (start, end, qualifiesHighHumidity(p) ? .highHumidity : .optimal)
        }.sorted { $0.0 < $1.0 }
        var result: [SprayForecastWindow] = []
        for (start, end, kind) in slots {
            if let last = result.last, last.end == start, last.kind == kind {
                result[result.count - 1] = SprayForecastWindow(start: last.start, end: end, kind: kind)
            } else {
                result.append(SprayForecastWindow(start: start, end: end, kind: kind))
            }
        }
        return result
    }
}
